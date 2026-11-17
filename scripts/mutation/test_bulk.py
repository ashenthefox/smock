"""Tests of the bulk runs' steps (scripts/mutation/bulk.py), which the
workflow .github/workflows/mutation-runs.yml takes on GitHub Actions: the
plan, which chooses a run's mutants and its shards; a shard's run; and the
finish, which merges the shards into one report, or, for the timing of
mutants side by side, compares the runs (#313).

The rules come from #313's acceptance criteria and from #275 ("Bulk runs
go to Actions, in a workflow that runs on a schedule or by hand ... They
are sharded within the account's 20 concurrent jobs and 6 hours per job,
with the width as an input"); where they were silent, CONTRIBUTING.md
("Mutation runner", "Bulk runs on Actions") says what was decided, and the
tests cite it. The outcomes of the fixture's mutants are those its
comments give, as in test_mutation.py.

The plan's tests run the site finder, so they need moonc; the runs need
python3, git, moon and moonc (the toolchain of .moonbit-version), as
test_mutation.py does.

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
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
BULK = HERE / "bulk.py"
RUN = HERE / "run.py"
MERGE = HERE / "merge.py"

# The pure packages (CONTRIBUTING.md, "Terms"): the 19 of the test review's
# start and serverparsers; testcerts builds on wasm-gc but is data only.
PURE = ["buildinfo", "cookies", "definitions", "engine", "grpc", "http1", "importopenapi", "llm", "log", "metrics",
        "prng", "protobuf", "re2", "serverparsers", "settings", "template", "unicode", "usage", "xml", "yaml"]
# The fixture's packages whose code builds on wasm-gc (CONTRIBUTING.md,
# "Mutation runner": host and probe build only natively; dial and dots hold
# tests alone, so no site).
FIXTURE_PURE = ["bounds", "calc", "forms", "log", "meter", "same", "shapes", "units"]


def bulk(*args, cwd=None):
    """Runs bulk.py with args."""
    return subprocess.run([sys.executable, str(BULK), *map(str, args)], capture_output=True, text=True, cwd=cwd)


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def outputs(text):
    """The step outputs a plan prints, as GitHub's GITHUB_OUTPUT file takes
    them: one name=value per line."""
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


class PlanTest(unittest.TestCase):
    """Plans, which run the site finder and no mutant."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-plan-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def plan(self, name, *args, root=FIXTURE, ok=True):
        out = self.tmp / name
        result = bulk("plan", "--root", root, "--out", out, *args)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads((out / "plan.json").read_text()), outputs(result.stdout)
        return result

    def test_without_packages_a_run_takes_the_pure_packages_that_have_sites(self):
        plan, _ = self.plan("pure", "--mode", "packages")
        self.assertEqual(plan["packages"], FIXTURE_PURE)
        self.assertEqual(plan["args"], ["--set", "pinned", *FIXTURE_PURE])

    def test_smocks_pure_packages_are_those_of_contributings_terms(self):
        plan, _ = self.plan("smock", "--mode", "packages", root=REPO)
        self.assertEqual(plan["packages"], PURE)

    def test_each_mode_runs_the_runner_with_its_options(self):
        # #313: "a run of any mode (a seeded sample, a BODY pass, chosen
        # packages, the pinned or the full set, a listed set, a kill
        # matrix)".
        sample, _ = self.plan("sample", "--mode", "sample", "--size", "20", "--seed", "s1", "--packages", "calc log")
        self.assertEqual(sample["args"], ["--set", "pinned", "--sample", "20", "--seed", "s1", "calc", "log"])
        self.assertEqual(sample["mutants"], 20)
        body, _ = self.plan("body", "--mode", "body", "--packages", "calc log")
        self.assertEqual(body["args"], ["--set", "pinned", "--operator", "BODY", "calc", "log"])
        # calc's four functions and log's three (test_mutation.py's CALC
        # and LOG).
        self.assertEqual(body["mutants"], 7)
        full, _ = self.plan("full", "--mode", "packages", "--set", "full", "--packages", "calc")
        self.assertEqual(full["args"], ["--set", "full", "calc"])
        self.assertEqual(full["mutants"], 31)
        kill_matrix, _ = self.plan("matrix", "--mode", "matrix", "--packages", "units")
        self.assertEqual(kill_matrix["args"], ["--matrix", "--set", "pinned", "units"])
        listed = self.tmp / "listed.jsonl"
        listed.write_text(json.dumps({"file": "calc/calc.mbt", "definition": "is_odd", "operator": "NOT",
                                      "original": "!", "replacement": "", "ordinal": 0}) + "\n")
        by_list, _ = self.plan("list", "--mode", "list", "--list", listed)
        self.assertEqual(by_list["args"], ["--list", str(listed)])
        self.assertEqual((by_list["packages"], by_list["mutants"]), (["calc"], 1))

    def test_a_run_holds_at_most_the_width_of_shards_at_once_and_at_most_20(self):
        # #313: "the width (how many shards run at once, up to 20)".
        plan, out = self.plan("width", "--mode", "packages", "--packages", "calc log", "--width", "3")
        self.assertEqual(plan["mutants"], 25 + 6)
        self.assertEqual(json.loads(out["shards"]), [
            {"name": "1-of-3", "index": 1, "count": 3, "workers": 1},
            {"name": "2-of-3", "index": 2, "count": 3, "workers": 1},
            {"name": "3-of-3", "index": 3, "count": 3, "workers": 1}])
        self.assertEqual(out["width"], "3")
        for width in ("21", "0", "x"):
            result = self.plan(f"width-{width}", "--mode", "packages", "--packages", "calc", "--width", width,
                               ok=False)
            self.assertEqual(result.returncode, 2, width)
            self.assertIn("--width", result.stderr)

    def test_a_run_has_no_more_shards_than_mutants(self):
        plan, out = self.plan("few", "--mode", "body", "--packages", "calc", "--width", "20")
        self.assertEqual(len(json.loads(out["shards"])), 4)
        self.assertEqual(out["width"], "4")

    def test_each_shard_is_planned_to_end_within_the_jobs_six_hours(self):
        # #313: "shards the run within 6 hours per job". CONTRIBUTING: each
        # shard's mutants at the planned time a mutant take at most 5 of
        # the job's 6 hours; with an hour a mutant, 5 mutants a shard, so
        # more shards than the width, which run as jobs come free.
        plan, out = self.plan("budget", "--mode", "packages", "--packages", "calc log", "--width", "2",
                              "--seconds-per-mutant", "3600")
        shards = json.loads(out["shards"])
        self.assertEqual(len(shards), 7)
        self.assertEqual(out["width"], "2")
        self.assertEqual((plan["budget_s"], plan["seconds_per_mutant"]), (5 * 3600, 3600))

    def test_more_shards_than_a_matrix_holds_and_a_mutant_longer_than_a_shard_are_refused(self):
        # GitHub's matrix makes at most 256 jobs; engine has more mutants
        # than that, at one mutant a shard.
        result = self.plan("too-many", "--mode", "packages", "--packages", "engine", "--seconds-per-mutant",
                           str(5 * 3600), root=REPO, ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("more than the 256 jobs a matrix holds", result.stderr)
        result = self.plan("too-long", "--mode", "packages", "--packages", "calc", "--seconds-per-mutant",
                           str(5 * 3600 + 1), ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("a mutant planned at 18001 s does not fit in a shard's 18000 s", result.stderr)

    def test_mutants_built_side_by_side_on_one_runner(self):
        plan, out = self.plan("workers", "--mode", "packages", "--packages", "log", "--width", "2", "--workers", "4")
        self.assertEqual({s["workers"] for s in json.loads(out["shards"])}, {4})
        # #313: "times one shard with 1, 2 and 4 mutants built and tested
        # side by side on one runner": one shard of the whole selection,
        # run three times.
        timing, out = self.plan("timing", "--mode", "timing", "--size", "4", "--seed", "t", "--packages", "log")
        self.assertEqual(timing["args"], ["--set", "pinned", "--sample", "4", "--seed", "t", "log"])
        self.assertEqual(json.loads(out["shards"]), [
            {"name": "workers-1", "index": 1, "count": 1, "workers": 1},
            {"name": "workers-2", "index": 1, "count": 1, "workers": 2},
            {"name": "workers-4", "index": 1, "count": 1, "workers": 4}])

    def test_a_package_the_finder_cannot_read_and_a_missing_list_stop_the_plan(self):
        result = self.plan("missing", "--mode", "packages", "--packages", "nothing-here", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("nothing-here", result.stderr)
        result = self.plan("no-list", "--mode", "list", ok=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--mode list needs --list", result.stderr)

    def test_a_package_the_sample_leaves_out_is_still_one_of_the_runs(self):
        # A sample of 1 of calc's 25 and log's 6 mutants takes calc's: log
        # is still among the packages the run is over.
        plan, _ = self.plan("one", "--mode", "sample", "--size", "1", "--packages", "calc log")
        self.assertEqual(plan["packages"], ["calc", "log"])
        self.assertEqual({d: p["mutants"] for d, p in plan["per_package"].items()}, {"calc": 1, "log": 0})
        self.assertIn("of the pinned set over 2 packages: 1 mutant,", (self.tmp / "one" / "plan.md").read_text())

    def test_the_plan_says_what_it_runs(self):
        plan, _ = self.plan("said", "--mode", "sample", "--size", "10", "--seed", "7", "--packages", "calc log",
                            "--width", "2")
        text = (self.tmp / "said" / "plan.md").read_text()
        self.assertIn("A seeded sample of 10 mutants (seed 7) of the pinned set over 2 packages: 10 mutants,", text)
        self.assertIn("in 2 shards, at most 2 at once, 1 mutant at a time on each runner", text)
        self.assertIn("| calc |", text)


def without_timings(text):
    """A report with each time in seconds written as N."""
    return re.sub(r"\d+\.\d+ s\b", "N s", text)


class RunTest(unittest.TestCase):
    """A plan of log's full set in two shards, both shards' runs, and the
    finish that merges them, beside the same run without shards."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-run-"))
        cls.root = cls.tmp / "root"
        shutil.copytree(FIXTURE, cls.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        result = bulk("plan", "--root", cls.root, "--out", cls.tmp / "plan", "--mode", "packages", "--set", "full",
                      "--packages", "log", "--width", "2")
        if result.returncode != 0:
            raise AssertionError(f"plan failed:\n{result.stderr}")
        cls.plan = cls.tmp / "plan" / "plan.json"
        cls.shards = []
        for name in ("1-of-2", "2-of-2"):
            out = cls.tmp / name
            result = bulk("shard", "--plan", cls.plan, "--name", name, "--root", cls.root, "--work",
                          cls.tmp / f"work-{name}", "--out", out)
            if result.returncode != 0:
                raise AssertionError(f"shard {name} failed:\n{result.stderr}")
            cls.shards.append(out)
        cls.whole = cls.tmp / "whole"
        result = subprocess.run([sys.executable, str(RUN), "--root", str(cls.root), "--work", str(cls.tmp / "work"),
                                 "--out", str(cls.whole), "--set", "full", "log"], capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(f"run.py failed:\n{result.stderr}")
        cls.jobs = cls.tmp / "jobs.jsonl"
        cls.jobs.write_text("".join(json.dumps(j) + "\n" for j in [
            {"name": "plan", "started_at": "2026-11-18T01:00:00Z", "completed_at": "2026-11-18T01:01:00Z",
             "conclusion": "success"},
            {"name": "shard 1-of-2", "started_at": "2026-11-18T01:01:10Z", "completed_at": "2026-11-18T01:11:10Z",
             "conclusion": "success"},
            {"name": "shard 2-of-2", "started_at": "2026-11-18T01:01:20Z", "completed_at": "2026-11-18T01:21:20Z",
             "conclusion": "success"},
            # The finish itself, which is running.
            {"name": "finish", "started_at": "2026-11-18T01:21:30Z", "completed_at": None, "conclusion": None},
        ]))
        cls.finished = cls.tmp / "finished"
        cls.result = bulk("finish", "--plan", cls.plan, "--out", cls.finished, "--jobs", cls.jobs, "--run-url",
                          "https://github.com/o/r/actions/runs/1", *cls.shards)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_shard_runs_its_part_and_says_how_long_it_took(self):
        records = [read_lines(s / "mutants.jsonl") for s in self.shards]
        self.assertEqual([len(r) for r in records], [4, 4])
        for index, shard in enumerate(self.shards, 1):
            done = json.loads((shard / "bulk.json").read_text())
            self.assertEqual((done["index"], done["count"], done["workers"], done["status"]), (index, 2, 1, 0))
            self.assertGreater(done["wall_s"], 0)
            self.assertTrue(done["machine"])

    def test_the_finish_merges_the_shards_into_the_report_of_the_run_without_shards(self):
        # #313: "merges the shards' reports into one artifact".
        self.assertEqual(self.result.returncode, 0, self.result.stderr)

        def records(out):
            return [{k: v for k, v in r.items() if k != "timings"} for r in read_lines(out / "mutants.jsonl")]

        self.assertEqual(records(self.finished), records(self.whole))
        report = (self.finished / "report.md").read_text()
        whole = (self.whole / "report.md").read_text()
        self.assertTrue(without_timings(report).endswith(without_timings(whole)))
        self.assertTrue((self.finished / "summary.json").is_file())

    def test_the_report_starts_with_the_run_its_times_and_a_line_per_package(self):
        report = (self.finished / "report.md").read_text()
        self.assertTrue(report.startswith("# Mutation run: chosen packages\n\n"
                                          "[The run on GitHub Actions](https://github.com/o/r/actions/runs/1):"
                                          " the full set over 1 package, in 2 shards, at most 2 at once, 1 mutant"
                                          " at a time on each runner.\n"), report[:400])
        # #313: "the runs' links and their wall and runner times". The
        # finish's own job is still running, so it is left out.
        self.assertIn("Wall time 21 min 20 s, from the first job's start to the last job's end; runner time"
                      " 31 min, the 3 jobs' times added up.", report)
        # #313: "Per package: mutants, killed, timed out, unviable,
        # survived, kill rate (reported, never gated), skipped sites by
        # rule, and the pseudo-tested functions." log's full set: 8
        # mutants, 6 killed and 2 survivors (test_mutation.py's LOG), no
        # exclusion entry, and 3 sites skipped, which its section names by
        # rule: line's `+` on a string (lines.mbt's comment) and target.mbt's
        # literal, outside STR's scope in both of its alternatives.
        self.assertIn("| package | mutants | killed | timed out | survived | unexplained | stale-covered | unviable"
                      " | unconfirmed | kill rate | pseudo-tested | skipped sites |\n", report)
        self.assertIn("| mutation/fixture/log | 8 | 6 | 0 | 2 | 2 | 0 | 0 | 0 | 75.0% | 0 of 3 | 3 |\n", report)
        self.assertIn("| all | 8 | 6 | 0 | 2 | 2 | 0 | 0 | 0 | 75.0% | 0 of 3 | 3 |\n", report)
        self.assertIn("Sites skipped in this set: AOR string operand 1, STR outside scope 2.", report)
        self.assertIn("The kill rate is reported, never gated.", report)
        # It prints the report, for the job summary.
        self.assertEqual(self.result.stdout, report + "\n")

    def test_a_missing_shard_fails_the_finish(self):
        result = bulk("finish", "--plan", self.plan, "--out", self.tmp / "half", self.shards[0])
        self.assertEqual(result.returncode, 1)
        self.assertIn("shard 2/2 is missing", result.stderr)


class TimingTest(unittest.TestCase):
    """The timing of one shard with 1, 2 and 4 mutants built and tested
    side by side (#313), on a sample of 4 of log's mutants."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-timing-"))
        cls.root = cls.tmp / "root"
        shutil.copytree(FIXTURE, cls.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        result = bulk("plan", "--root", cls.root, "--out", cls.tmp / "plan", "--mode", "timing", "--size", "4",
                      "--seed", "t", "--packages", "log")
        if result.returncode != 0:
            raise AssertionError(f"plan failed:\n{result.stderr}")
        cls.plan = cls.tmp / "plan" / "plan.json"
        cls.runs = []
        for name in ("workers-1", "workers-2", "workers-4"):
            out = cls.tmp / name
            result = bulk("shard", "--plan", cls.plan, "--name", name, "--root", cls.root, "--work",
                          cls.tmp / f"work-{name}", "--out", out)
            if result.returncode != 0:
                raise AssertionError(f"{name} failed:\n{result.stderr}")
            cls.runs.append(out)
        cls.finished = cls.tmp / "finished"
        cls.result = bulk("finish", "--plan", cls.plan, "--out", cls.finished, *cls.runs)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_run_takes_its_mutants_at_a_time(self):
        self.assertEqual([json.loads((r / "bulk.json").read_text())["workers"] for r in self.runs], [1, 2, 4])
        ids = [[r["id"] for r in read_lines(run / "mutants.jsonl")] for run in self.runs]
        self.assertEqual(len(ids[0]), 4)
        self.assertEqual(ids[1], ids[0])
        self.assertEqual(ids[2], ids[0])

    def test_the_report_gives_the_time_per_mutant_for_each(self):
        # #313: "posts the time per mutant for each".
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        report = (self.finished / "report.md").read_text()
        self.assertTrue(report.startswith("# Mutants side by side on one runner\n\n"), report[:200])
        self.assertIn("| mutants at once | mutants | the shard's run | per mutant | against one at a time |\n", report)
        for workers in (1, 2, 4):
            self.assertRegex(report, rf"\n\| {workers} \| 4 \| [0-9][^|]* s \| \d+\.\d s \| \d\.\d\d \|\n")
        self.assertIn("The three runs gave each mutant the same outcome.", report)
        timing = json.loads((self.finished / "timing.json").read_text())
        self.assertEqual([t["workers"] for t in timing["runs"]], [1, 2, 4])
        for run in timing["runs"]:
            # The shard's run over its mutants, to the millisecond.
            self.assertEqual(run["per_mutant_s"], round(run["wall_s"] / 4, 3))


if __name__ == "__main__":
    unittest.main()
