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

    def test_a_scheduled_run_takes_its_mode_from_its_schedule_and_the_defaults_of_the_rest(self):
        # #314: "Weekly: the pinned set over the pure packages"; "Monthly
        # ...: the full set over the pure packages". A scheduled run has no
        # inputs: GitHub gives each as empty.
        empty = ["--mode", "", "--packages", "", "--set", "", "--seed", "", "--size", "", "--width", "",
                 "--workers", ""]
        weekly, out = self.plan("weekly", "--schedule", "23 20 * * 5", *empty)
        self.assertEqual((weekly["mode"], weekly["args"]), ("weekly", ["--set", "pinned", *FIXTURE_PURE]))
        self.assertEqual((out["mode"], out["width"]), ("weekly", "20"))
        monthly, out = self.plan("monthly", "--schedule", "43 22 1 * *", *empty)
        self.assertEqual((monthly["mode"], monthly["args"]), ("monthly", ["--set", "full", *FIXTURE_PURE]))
        self.assertEqual(out["mode"], "monthly")
        # Started by hand: the weekly run, and the monthly run before a
        # release.
        by_hand, _ = self.plan("monthly-by-hand", "--mode", "monthly", "--packages", "calc")
        self.assertEqual(by_hand["args"], ["--set", "full", "calc"])
        result = self.plan("other-schedule", "--schedule", "0 0 * * *", ok=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no run is planned for the schedule 0 0 * * *", result.stderr)

    def test_the_weekly_run_reads_the_flake_records_of_the_latest_weekly_run(self):
        # #301's records live in the report artifact of the latest weekly
        # run, which the next weekly run passes to the runner
        # (CONTRIBUTING.md, "Flake rates").
        records = self.tmp / "latest-flakes.json"
        records.write_text('{"version": 1, "runs": []}\n')
        weekly, _ = self.plan("weekly-flakes", "--mode", "weekly", "--packages", "log", "--flakes", records)
        self.assertEqual(weekly["flakes"], "flakes.json")
        self.assertEqual((self.tmp / "weekly-flakes" / "flakes.json").read_text(), records.read_text())
        # The first weekly run has none to read.
        first, _ = self.plan("weekly-first", "--mode", "weekly", "--packages", "log", "--flakes",
                             self.tmp / "none.json")
        self.assertIsNone(first["flakes"])
        self.assertIn("No flake records of an earlier weekly run", (self.tmp / "weekly-first" / "plan.md").read_text())
        # Only the weekly run reads them.
        other, _ = self.plan("sample-flakes", "--mode", "sample", "--size", "2", "--packages", "log", "--flakes",
                             records)
        self.assertIsNone(other["flakes"])
        self.assertFalse((self.tmp / "sample-flakes" / "flakes.json").exists())

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
        # the job's 6 hours; with an hour a mutant, 5 mutants a shard: 7
        # shards for 31 mutants, more than the width, so they run in waves
        # as jobs come free, and 8, which fill both waves of 2, end the
        # run sooner than 7, whose last would run alone.
        plan, out = self.plan("budget", "--mode", "packages", "--packages", "calc log", "--width", "2",
                              "--seconds-per-mutant", "3600")
        shards = json.loads(out["shards"])
        self.assertEqual(len(shards), 8)
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
        self.assertIn("| package | mutants | killed | timed out | survived | unexplained | of them stale-covered"
                      " | unviable | unconfirmed | kill rate | pseudo-tested | skipped sites |\n", report)
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


class PackageRowsTest(unittest.TestCase):
    """The report's line of a package, built by hand from a summary like
    the one test_mutation.py's RunnerTest gets of calc: 9 survivors, of
    which the fixture's exclusion list accepts one, defers one and covers
    one with a stale entry."""

    def test_stale_covered_and_deferred_survivors_count_as_unexplained(self):
        # #314: "unexplained survivors (DEFERRED-covered ones included),
        # stale-covered survivors with their stale entries' ids (counted as
        # unexplained)"; CONTRIBUTING.md, "Terms": the weekly run treats a
        # stale-covered survivor as unexplained.
        import bulk

        summary = {"packages": [{
            "package": "mutation/fixture/calc", "mutants": 25, "killed": 14, "timed_out": 1, "survived": 9,
            "unviable": 1, "unconfirmed": 0, "score": 0.625, "skipped": {},
            "exclusions": {"unexplained": 7, "stale_covered": 1, "accepted": 1,
                           "accepted_by_category": {"ARID": 1}},
            "body_mutants": 4, "pseudo_tested": [{"definition": "halve_until"}]}]}
        rows = bulk.package_rows(summary)
        self.assertEqual(rows[2], "| mutation/fixture/calc | 25 | 14 | 1 | 9 | 8 | 1 | 1 | 0 | 62.5% | 1 of 4 | 0 |")


def plan_shards_finish(tmp, root, *plan_args):
    """Plans a run on root, runs its shards and finishes it: the plan's
    file, the shards' outputs, and the finish's output and result."""
    result = bulk("plan", "--root", root, "--out", tmp / "plan", *plan_args)
    if result.returncode != 0:
        raise AssertionError(f"plan failed:\n{result.stderr}")
    plan = tmp / "plan" / "plan.json"
    shards = []
    for shard in json.loads(plan.read_text())["shards"]:
        out = tmp / shard["name"]
        result = bulk("shard", "--plan", plan, "--name", shard["name"], "--root", root, "--work",
                      tmp / f"work-{shard['name']}", "--out", out)
        if result.returncode != 0:
            raise AssertionError(f"shard {shard['name']} failed:\n{result.stderr}")
        shards.append(out)
    finished = tmp / "finished"
    return plan, shards, finished, bulk("finish", "--plan", plan, "--out", finished, *shards)


class WeeklyTest(unittest.TestCase):
    """A weekly run of log's pinned set, which reads the flake records of
    an earlier run (#314)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-weekly-"))
        cls.root = cls.tmp / "root"
        shutil.copytree(FIXTURE, cls.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        # An earlier run's flake records, as the latest weekly run keeps
        # them.
        earlier = subprocess.run([sys.executable, str(RUN), "--root", str(cls.root), "--work", str(cls.tmp / "w0"),
                                  "--out", str(cls.tmp / "earlier"), "log"], capture_output=True, text=True)
        if earlier.returncode != 0:
            raise AssertionError(f"run.py failed:\n{earlier.stderr}")
        cls.plan, cls.shards, cls.finished, cls.result = plan_shards_finish(
            cls.tmp, cls.root, "--mode", "weekly", "--packages", "log", "--width", "2", "--flakes",
            cls.tmp / "earlier" / "flakes.json")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_each_shard_reads_the_flake_records_and_the_merge_keeps_this_runs_too(self):
        for shard in self.shards:
            flakes = json.loads((shard / "summary.json").read_text())["flakes"]
            self.assertEqual(flakes["runs_read"], 1)
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        # The earlier run's record and this run's, which the next weekly
        # run reads.
        merged = json.loads((self.finished / "flakes.json").read_text())
        self.assertEqual(len(merged["runs"]), 2)

    def test_the_report_names_the_weekly_run_and_counts_stale_covered_survivors_as_unexplained(self):
        report = (self.finished / "report.md").read_text()
        self.assertTrue(report.startswith("# Mutation run: the weekly run\n\n"), report[:200])
        self.assertIn("the pinned set over 1 package", report)
        self.assertIn("Stale-covered survivors, and those that a DEFERRED entry covers, count as unexplained,"
                      " as L4 counts them.", report)
        self.assertIn("This run read the flake records of 1 earlier run.", report)


class MonthlyTest(unittest.TestCase):
    """A monthly run of log's full set (#314)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-monthly-"))
        cls.root = cls.tmp / "root"
        shutil.copytree(FIXTURE, cls.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        cls.plan, cls.shards, cls.finished, cls.result = plan_shards_finish(
            cls.tmp, cls.root, "--mode", "monthly", "--packages", "log", "--width", "1")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_the_report_gives_the_survivors_at_the_pinned_alternatives_and_at_the_others_apart(self):
        # #314: "the full set over the pure packages, with survivors at the
        # pinned alternatives and at the other alternatives given apart.
        # The monthly run is report-only". log's full set: one survivor at
        # a pinned alternative (cut_mark's "_") and one at another
        # (is_comment's ""), test_mutation.py's LOG.
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        report = (self.finished / "report.md").read_text()
        self.assertTrue(report.startswith("# Mutation run: the monthly run\n\n"), report[:200])
        self.assertIn("This run is report-only: its survivors at the other alternatives stop no merge and no"
                      " release, and do not count towards L4 (decision 7).", report)
        self.assertIn("| package | unexplained at the pinned alternatives | at the other alternatives |\n"
                      "|---|---:|---:|\n"
                      "| mutation/fixture/log | 1 | 1 |\n", report)
        self.assertIn("### Survivors at the pinned alternatives (1)", report)
        self.assertIn("### Survivors at the other alternatives (1)", report)


class StaleTest(unittest.TestCase):
    """The stale entries of the exclusion list, which the weekly run lists
    for their re-triage in a batch (#314)."""

    def test_the_stale_entries_are_counted_and_listed_with_their_categories(self):
        # The fixture's list holds one stale entry, for calc's
        # `halve_until` INT survivor (test_mutation.py's RunnerTest).
        with tempfile.TemporaryDirectory(prefix="test-bulk-stale-") as tmp:
            out = Path(tmp) / "stale.md"
            result = bulk("stale", "--root", FIXTURE, "--out", out)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs(result.stdout), {"stale": "1"})
            text = out.read_text()
            self.assertIn("- `calc/calc.mbt,halve_until,INT,2,3,0` (ARID)\n", text)
            self.assertIn("1 entry of the exclusion list is stale", text)

    def test_a_list_without_stale_entries_lists_none(self):
        with tempfile.TemporaryDirectory(prefix="test-bulk-stale-none-") as tmp:
            root = Path(tmp) / "root"
            shutil.copytree(FIXTURE, root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
            (root / "exclusions.toml").write_text("")
            result = bulk("stale", "--root", root, "--out", Path(tmp) / "stale.md")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs(result.stdout), {"stale": "0"})


class SeedsTest(unittest.TestCase):
    """The properties with random seeds (#314), on a small module of two
    packages, each with a seed constant, and with a moon that fails one
    file's tests."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-seeds-"))
        root = cls.root = cls.tmp / "root"
        (root / "pure").mkdir(parents=True)
        (root / "native").mkdir()
        (root / "moon.mod.json").write_text('{ "name": "seeds" }\n')
        (root / "pure" / "moon.pkg").write_text("")
        (root / "native" / "moon.pkg").write_text('supported_targets = "native"\n')
        (root / "pure" / "round_test.mbt").write_text(
            "///|\n/// The seed of the round trip.\nconst ROUND_SEED : UInt64 = 1\n")
        (root / "native" / "wire_test.mbt").write_text(
            "///|\n/// The seed of the wire property.\nconst WIRE_SEED : UInt64 = 2\n")
        cls.log = cls.tmp / "moon.log"
        cls.moon = cls.tmp / "moon"
        cls.moon.write_text(f'#!/bin/sh\necho "$*" >>"{cls.log}"\n'
                            'case "$*" in *native/wire_test.mbt*) echo "property failed"; exit 1 ;; esac\n')
        cls.moon.chmod(0o755)
        cls.out = cls.tmp / "out"
        cls.result = bulk("seeds", "--root", root, "--out", cls.out, "--moon", cls.moon)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def seed(self, path, name):
        return re.search(rf"{name} : UInt64 = (\d+)", (self.root / path).read_text()).group(1)

    def test_each_property_runs_with_a_random_seed_on_its_packages_target(self):
        # #314: "A separate job writes a random seed into a working copy of
        # each property, runs the properties, and prints the seeds".
        self.assertEqual(self.log.read_text().splitlines(), ["test --target native native/wire_test.mbt",
                                                             "test --target wasm-gc pure/round_test.mbt"])
        report = (self.out / "report.md").read_text()
        for path, name in (("pure/round_test.mbt", "ROUND_SEED"), ("native/wire_test.mbt", "WIRE_SEED")):
            seed = self.seed(path, name)
            self.assertIn(f"`{name}` = {seed}", report)
            self.assertIn(seed, self.result.stdout)

    def test_a_failure_is_reported_with_its_seed_and_fails_the_job(self):
        # #314: "a failure there is reported with its seed"; CONTRIBUTING.md,
        # "Seeds": "To rerun a printed seed, set the constant to it and run
        # the property's test".
        self.assertEqual(self.result.returncode, 1)
        seed = self.seed("native/wire_test.mbt", "WIRE_SEED")
        report = (self.out / "report.md").read_text()
        self.assertIn(f"- native/wire_test.mbt:3: `WIRE_SEED` = {seed}: failed. To run it again, set `WIRE_SEED` to"
                      f" {seed} and run `moon test --target native native/wire_test.mbt`.", report)
        self.assertIn(f"- pure/round_test.mbt:3: `ROUND_SEED` = {self.seed('pure/round_test.mbt', 'ROUND_SEED')}:"
                      " passed.", report)
        self.assertIn("property failed", report)


def survivor(package, file, line, status="unexplained"):
    """A record of a survivor, as the runner writes it."""
    return {"id": f"{file},f{line},INT,1,2,0", "package": f"smock/{package}", "file": file, "definition": f"f{line}",
            "line": line, "outcome": "survived", "exclusion": {"status": status}}


class TriageTest(unittest.TestCase):
    """Stage 1's triage tickets from a weekly run's records (#314), made
    by hand: a closing ticket with more than 40 unexplained survivors gets
    tickets of at most 40, never splitting a source file that holds
    fewer."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-bulk-triage-"))
        report = cls.tmp / "report"
        report.mkdir()
        records = ([survivor("yaml", "yaml/a.mbt", n) for n in range(1, 31)]
                   + [survivor("yaml", "yaml/b.mbt", n) for n in range(1, 16)]
                   + [survivor("yaml", "yaml/c.mbt", n) for n in range(1, 51)]
                   # Accepted survivors do not count; stale-covered ones do.
                   + [survivor("yaml", "yaml/b.mbt", n, "accepted") for n in range(100, 110)]
                   + [survivor("yaml", "yaml/b.mbt", 200, "stale-covered")]
                   + [survivor("http1", "http1/a.mbt", n) for n in range(1, 41)]
                   + [survivor("cookies", "cookies/c.mbt", n) for n in range(1, 26)]
                   + [survivor("metrics", "metrics/m.mbt", n) for n in range(1, 21)]
                   + [dict(survivor("re2", "re2/r.mbt", 1), outcome="killed")])
        (report / "mutants.jsonl").write_text("".join(json.dumps(r) + "\n" for r in records))
        bodies = cls.tmp / "bodies"
        bodies.mkdir()
        (bodies / "323.md").write_text(
            "## Acceptance criteria\n\n- [ ] **Triage.** Every survivor in yaml has a class.\n"
            "- [ ] **Kills.** A test takes its expected value from a named source.\n"
            "- [ ] **Exclusions** go through the three-step route.\n- [ ] **Code** is deleted only so.\n"
            "- [ ] **No weakening.** No existing test is deleted.\n- [ ] **L4.** The weekly run shows zero.\n"
            "- [ ] **Snapshot audit.** Its Triage of disagreements and its Code are the maintainer's.\n")
        cls.out = cls.tmp / "tickets"
        cls.result = bulk("triage", "--report", report, "--bodies", bodies, "--out", cls.out)
        cls.tickets = json.loads((cls.out / "tickets.json").read_text())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_a_closing_ticket_with_more_than_40_survivors_is_split_by_source_file(self):
        self.assertEqual(self.result.returncode, 0, self.result.stderr)
        yaml = [t for t in self.tickets if t["closing"] == 323]
        # a.mbt's 30 alone, b.mbt's 16 (its stale-covered one included),
        # and c.mbt's 50, which a ticket cannot hold, in two halves.
        self.assertEqual([(t["files"], len(t["survivors"])) for t in yaml],
                         [(["yaml/a.mbt"], 30), (["yaml/b.mbt"], 16), (["yaml/c.mbt"], 25), (["yaml/c.mbt"], 25)])
        self.assertIn("yaml/b.mbt,f200,INT,1,2,0", yaml[1]["survivors"])
        # cookies and metrics share #328: 45 together, so two tickets.
        self.assertEqual([(t["files"], len(t["survivors"])) for t in self.tickets if t["closing"] == 328],
                         [(["cookies/c.mbt"], 25), (["metrics/m.mbt"], 20)])

    def test_a_closing_ticket_with_at_most_40_gets_none(self):
        self.assertEqual([t for t in self.tickets if t["closing"] == 324], [])
        summary = (self.out / "tickets.md").read_text()
        self.assertIn("| #324 | http1 | 40 | none: triaged in #324 |", summary)
        self.assertIn("| #323 | yaml | 96 | 4 |", summary)

    def test_each_ticket_lists_its_survivors_and_carries_the_closing_tickets_triage_criteria(self):
        # #314: "Each lists the ids of its survivors, ... carries its
        # closing ticket's triage criteria (Triage, Kills, Exclusions, Code,
        # No weakening) for those items only, and records the agent time
        # spent when it closes."
        first = self.tickets[0]
        body = (self.out / first["body"]).read_text()
        self.assertIn("## Parent\n\n#323\n", body)
        self.assertIn("- `yaml/a.mbt,f1,INT,1,2,0`\n", body)
        self.assertIn("- [ ] **Triage.** Every survivor in yaml has a class.\n", body)
        self.assertIn("- [ ] **No weakening.** No existing test is deleted.\n", body)
        self.assertNotIn("**L4.**", body)
        self.assertNotIn("**Snapshot audit.**", body)
        self.assertIn("For the 30 survivors above only.", body)
        self.assertIn("- [ ] The agent time spent is recorded on this ticket when it closes.", body)
        self.assertIn("## Blocked by\n\n- #314\n- #315\n", body)
        self.assertEqual(first["title"], "Triage the survivors of yaml in yaml/a.mbt (1 of 4)")
        self.assertEqual(first["labels"], ["ready-for-agent"])

    def test_settings_triage_tickets_are_blocked_by_its_in_process_tests_too(self):
        # #314: "Each is blocked by this ticket, #315, and #320 for
        # settings".
        with tempfile.TemporaryDirectory(prefix="test-bulk-triage-settings-") as tmp:
            report = Path(tmp) / "report"
            report.mkdir()
            (report / "mutants.jsonl").write_text(
                "".join(json.dumps(survivor("settings", "settings/s.mbt", n)) + "\n" for n in range(1, 42)))
            result = bulk("triage", "--report", report, "--out", Path(tmp) / "tickets")
            self.assertEqual(result.returncode, 0, result.stderr)
            tickets = json.loads((Path(tmp) / "tickets" / "tickets.json").read_text())
            self.assertEqual([(t["closing"], t["blocked_by"]) for t in tickets],
                             [(329, [314, 315, 320]), (329, [314, 315, 320])])
            # Without the closing ticket's text, its criteria are named.
            body = (Path(tmp) / "tickets" / tickets[0]["body"]).read_text()
            self.assertIn("#329's criteria Triage, Kills, Exclusions, Code and No weakening", body)


if __name__ == "__main__":
    unittest.main()
