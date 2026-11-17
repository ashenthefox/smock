"""Tests of the mutation runner's canary (scripts/mutation/canary.py), which
replays the sample's 250 mutants on the commit they were sampled from and
compares each verdict with the recorded one (#308).

The rules come from #308's acceptance criteria and from #275 ("A weekly
canary replays the prototype's 250 mutants, whose verdicts are known, on
d953f320 with the toolchain pinned there; the maintainer accepts each
explained difference"); where they were silent, CONTRIBUTING.md
("Mutation runner", "The canary") says what was decided, and the tests
cite it.

The tests of the committed data need the history down to d953f320 (a
clone with all of it, as CI's job checks makes); those of the site finder
and of a replay need python3, git, moon and moonc (the toolchain of
.moonbit-version), as test_mutation.py does.

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import collections
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FIXTURE = HERE / "fixture"
CANARY = HERE / "canary.py"
DATA = REPO / "mutation" / "canary" / "mutants.jsonl"
COMMIT = "d953f320e0bb4fad15352224d01c365a02c0ab79"


def read_lines(path):
    """The JSON objects of a file of JSON lines."""
    return [json.loads(line) for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()]


def write_lines(path, objects):
    """Writes JSON objects to a file, one per line."""
    Path(path).write_text("".join(json.dumps(o, ensure_ascii=False) + "\n" for o in objects), encoding="utf-8")


def run_canary(*args, cwd=None):
    """Runs canary.py with args."""
    return subprocess.run([sys.executable, str(CANARY), *map(str, args)], capture_output=True, text=True, cwd=cwd)


class DataTest(unittest.TestCase):
    """The committed canary: the prototype's 250 mutants at d953f320, as the
    maintainer attached them to #308, with their recorded verdicts."""

    @classmethod
    def setUpClass(cls):
        cls.entries = read_lines(DATA)

    def test_it_holds_the_samples_250_mutants_with_the_verdicts_recorded_at_d953f320(self):
        # #275: "of 250 mutants sampled from the pure packages, 243
        # compiled", and "Of the 39 survivors read by hand"; its comment on
        # the step 1 replay: "83.9% with importers' tests at d953f320", that
        # is 204 of the 243 killed or timed out.
        self.assertEqual(len(self.entries), 250)
        self.assertEqual(len({e["name"] for e in self.entries}), 250)
        verdicts = collections.Counter(e["verdict"] for e in self.entries)
        self.assertEqual(250 - verdicts["unviable"], 243)
        self.assertEqual(verdicts["survived"], 39)
        self.assertEqual(verdicts["killed"] + verdicts["timed out"], 204)
        # The comment on the step 1 replay, its table's row "d953f320, own
        # tests (prototype)": 8 timed out.
        self.assertEqual(verdicts["timed out"], 8)
        # The packages of the sample, with as many mutants each as the
        # prototype's table of the sample gives, which the maintainer
        # attached with the mutants.
        packages = collections.Counter(posixpath.dirname(e["file"]) for e in self.entries)
        self.assertEqual(packages, {"prng": 25, "usage": 25, "metrics": 30, "grpc": 30, "cookies": 30,
                                    "yaml": 35, "template": 35, "engine": 40})

    def test_each_mutant_is_on_d953f320_where_it_says(self):
        # #308: "The 250 mutants (file, offset, replacement) ... at
        # d953f320": each one's original text is at its offset there.
        texts = {}
        for entry in self.entries:
            self.assertEqual(entry["commit"], COMMIT)
            if entry["file"] not in texts:
                result = subprocess.run(["git", "-C", str(REPO), "show", f"{COMMIT}:./{entry['file']}"],
                                        capture_output=True)
                self.assertEqual(result.returncode, 0, "the history must reach d953f320: git fetch --unshallow")
                texts[entry["file"]] = result.stdout.decode("utf-8")
            text = texts[entry["file"]]
            self.assertEqual(text[entry["offset"]:entry["offset"] + len(entry["original"])], entry["original"],
                             entry["name"])

    def test_each_mutant_names_its_v1_site_or_the_rule_that_leaves_it_out(self):
        # #308: "Each canary mutant within operator set v1 is among the
        # sites the current site finder produces"; CONTRIBUTING, "The
        # canary": a mutant within v1 names the site that makes it, and one
        # outside it names the rule of v1 that leaves it out.
        for entry in self.entries:
            self.assertEqual(("v1" in entry) + ("outside" in entry), 1, entry["name"])
            if "outside" in entry:
                self.assertRegex(entry["outside"], r"^(ROR|INT|LCR|DEL): ", entry["name"])


def git(repo, *args):
    """Runs git in repo, as an author of its own, and gives its output."""
    author = ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false"]
    result = subprocess.run(["git", "-C", str(repo), *author, *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed:\n{result.stderr}")
    return result.stdout


def fixture_history(directory, files=None):
    """A git repository at directory whose one commit holds a copy of the
    fixture module, the toolchain pin of this repository and the files
    given by path: the commit's id."""
    shutil.copytree(FIXTURE, directory, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
    shutil.copyfile(REPO / ".moonbit-version", directory / ".moonbit-version")
    for path, text in (files or {}).items():
        (directory / path).parent.mkdir(parents=True, exist_ok=True)
        (directory / path).write_text(text, encoding="utf-8")
    git(directory, "init", "-q", "-b", "main")
    git(directory, "add", "-A")
    git(directory, "commit", "-q", "-m", "the fixture")
    return git(directory, "rev-parse", "HEAD").strip()


def at(text, before, original):
    """The offset of original in text, where it follows before."""
    return text.index(before + original) + len(before)


class SitesTest(unittest.TestCase):
    """canary.py sites: the data against its commit, and against the site
    finder there."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-canary-sites-"))
        cls.repo = cls.tmp / "repo"
        cls.commit = fixture_history(cls.repo)
        # A list of explained differences that holds none.
        cls.explained = cls.tmp / "explained.toml"
        cls.explained.write_text("")
        calc = (FIXTURE / "calc" / "calc.mbt").read_text(encoding="utf-8")
        low = at(calc, "\n  low ", "<=")
        # calc.mbt's comments: ROR `low <= n` to `low < n` is killed; `>` is
        # not ROR's boundary alternative, so no site of v1 makes it.
        cls.within = entry("within", "killed", offset=low, commit=cls.commit,
                           v1="calc/calc.mbt,in_range,ROR,<=,<,0")
        cls.outside = entry("outside", "killed", offset=low, replacement=">", commit=cls.commit,
                            outside="ROR: only the boundary alternative, < with <= and > with >=")
        # A finder that no longer finds comparisons.
        cls.narrowed = cls.tmp / "narrowed.py"
        cls.narrowed.write_text(
            "import json, subprocess, sys\n"
            f"result = subprocess.run([sys.executable, {str(HERE / 'sites.py')!r}, *sys.argv[1:]],"
            " capture_output=True, text=True)\n"
            "for line in result.stdout.splitlines():\n"
            "    if json.loads(line)['operator'] != 'ROR':\n"
            "        print(line)\n"
            "sys.exit(result.returncode)\n")

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def sites(self, entries, *args):
        data = self.tmp / "mutants.jsonl"
        write_lines(data, entries)
        return run_canary("sites", "--repo", self.repo, "--data", data, "--explained", self.explained, *args)

    def test_the_committed_canary_is_what_the_site_finder_makes_on_d953f320(self):
        # #308: "Each canary mutant within operator set v1 is among the
        # sites the current site finder produces on d953f320".
        result = run_canary("sites")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("250 mutants on d953f320: 214 within operator set v1, each made by the site it names,"
                      " and 36 outside it, made by no site.", result.stdout)

    def test_a_mutant_within_v1_and_one_outside_it_check_out(self):
        result = self.sites([self.within, self.outside])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_narrowed_site_finder_fails_the_check(self):
        # #308: "one that is not fails the replay, so that a narrowed site
        # finder shows here".
        result = self.sites([self.within, self.outside], "--finder", f"{sys.executable} {self.narrowed}")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("within: the site finder makes no site calc/calc.mbt,in_range,ROR,<=,<,0", result.stdout)

    def test_a_site_that_makes_a_mutant_recorded_outside_v1_fails_the_check(self):
        # CONTRIBUTING, "The canary": a widened finder fails too.
        widened = dict(self.within, outside="ROR: made up")
        del widened["v1"]
        result = self.sites([widened])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("within: the site calc/calc.mbt,in_range,ROR,<=,<,0 makes it, though it is recorded"
                      " outside operator set v1 (ROR: made up)", result.stdout)

    def test_a_site_elsewhere_does_not_make_the_mutant(self):
        moved = dict(self.within, v1="calc/calc.mbt,in_range,ROR,<=,<,1")
        result = self.sites([moved])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("within: the site calc/calc.mbt,in_range,ROR,<=,<,1 is not at its place", result.stdout)

    def test_a_mutant_whose_text_is_not_at_its_offset_fails_the_check(self):
        result = self.sites([dict(self.within, offset=self.within["offset"] + 1)])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"within: calc/calc.mbt does not hold \"<=\" at offset {self.within['offset'] + 1}"
                      f" on {self.commit}", result.stdout)


def moon_log(directory):
    """A moon command that logs each of its command lines, and the log."""
    moon = shutil.which("moon")
    if moon is None:
        raise unittest.SkipTest("moon is not on PATH")
    log = directory / "moon.log"
    script = directory / "moon"
    script.write_text(f'#!/bin/sh\necho "$*" >>"{log}"\nexec "{moon}" "$@"\n')
    script.chmod(0o755)
    return script, log


class RunTest(unittest.TestCase):
    """canary.py run and install, on a canary of the fixture module's
    mutants, whose outcomes the fixture's comments give, in a git history
    of its own."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="test-canary-run-"))
        cls.repo = cls.tmp / "repo"
        cls.marker = cls.tmp / "installed"
        # The commit's own install script, which says how it was run.
        install = f'#!/bin/sh\necho "$* $(pwd)" >"{cls.marker}"\n'
        cls.commit = fixture_history(cls.repo, {"scripts/install-moonbit.sh": install})
        calc = (FIXTURE / "calc" / "calc.mbt").read_text(encoding="utf-8")
        same = (FIXTURE / "same" / "same.mbt").read_text(encoding="utf-8")
        body = same.index("{", same.index("pub fn count_a_if"))
        body_text = same[body : same.index("\n}\n", body) + 2]
        on = {"commit": cls.commit}
        # Each verdict as the fixture's comments give it.
        cls.entries = [
            entry("low", "killed", offset=at(calc, "\n  low ", "<="), v1="calc/calc.mbt,in_range,ROR,<=,<,0", **on),
            entry("high", "survived", offset=at(calc, "&& n ", "<="), v1="calc/calc.mbt,in_range,ROR,<=,<,1", **on),
            entry("halve", "unviable", offset=at(calc, "\n    ", "x = x / 2"), original="x = x / 2", replacement="",
                  operator="DEL", v1="calc/calc.mbt,halve_until,DEL,x = x / 2,,0", **on),
            # Outside v1, as the canary's ROR mutants that are not the
            # boundary alternative are: 1 is then outside the range from 1
            # to 3.
            entry("low-above", "killed", offset=at(calc, "\n  low ", "<="), replacement=">",
                  outside="ROR: only the boundary alternative, < with <= and > with >=", **on),
            # same.mbt: an equivalent mutant, and a duplicate of a killed one.
            entry("tracing", "survived", file="same/same.mbt", offset=at(same, "    if ", "TRACING"),
                  original="TRACING", replacement="false", operator="IFC",
                  v1="same/same.mbt,total,IFC,TRACING,false,0", tests=["mutation/fixture/same"], **on),
            entry("body", "killed", file="same/same.mbt", offset=body, original=body_text, replacement="{ 0 }",
                  operator="BODY", v1="same/same.mbt,count_a_if,BODY,{…},{ 0 },0",
                  tests=["mutation/fixture/same"], **on),
            entry("wanted", "killed", file="same/same.mbt", offset=at(same, "  if ", "wanted"), original="wanted",
                  replacement="false", operator="IFC", v1="same/same.mbt,count_a_if,IFC,wanted,false,0",
                  tests=["mutation/fixture/same"], **on),
        ]
        cls.data = cls.tmp / "mutants.jsonl"
        write_lines(cls.data, cls.entries)
        cls.explained = cls.tmp / "explained.toml"
        cls.explained.write_text("")
        cls.moon, cls.log = moon_log(cls.tmp)
        cls.work = cls.tmp / "work"
        cls.result = cls.run_canary_on(cls.data, "--work", cls.work)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @classmethod
    def run_canary_on(cls, data, *args, env=None):
        return subprocess.run([sys.executable, str(CANARY), "run", "--repo", str(cls.repo), "--data", str(data),
                               "--explained", str(cls.explained), "--moon", str(cls.moon), *map(str, args)],
                              capture_output=True, text=True, env=env)

    def test_the_replay_gives_the_recorded_verdicts_and_passes(self):
        # #308: "The runner replays them as a listed set on d953f320's
        # source, ... and compares each verdict with the recorded one. A
        # mutant that the compiler-output comparison marks equivalent
        # matches a recorded survivor."
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)
        summary = json.loads((self.work / "out" / "canary.json").read_text())
        self.assertEqual((summary["mutants"], summary["matched"], summary["unexplained"]), (7, 7, []))
        records = {r["listed"]["name"]: r for r in read_lines(self.work / "out" / "mutants.jsonl")}
        self.assertEqual({n: r["outcome"] for n, r in records.items()},
                         {"low": "killed", "high": "survived", "halve": "unviable", "low-above": "killed",
                          "tracing": "equivalent", "body": "killed", "wanted": "duplicate"})
        # As a listed set, with kill confirmation: the mutant outside v1
        # is named so, and each kill was run again.
        self.assertFalse(records["low-above"]["in_operator_set"])
        self.assertEqual(records["low"]["confirmation"], "confirmed")
        self.assertIn("sites: 7 mutants on", self.result.stdout)
        self.assertIn("Every verdict is the recorded one, or an explained difference.", self.result.stdout)

    def test_the_replay_runs_on_the_commits_source_in_a_checkout_of_its_own(self):
        source = self.work / "source"
        self.assertEqual(git(source, "rev-parse", "HEAD").strip(), self.commit)
        self.assertEqual(git(source, "status", "--porcelain"), "")
        # The runner's trees were copied from that checkout.
        self.assertTrue((self.work / "runner" / "tree-0" / "calc" / "calc.mbt").is_file())

    def test_a_replay_that_gives_another_verdict_fails(self):
        wrong = self.tmp / "wrong.jsonl"
        write_lines(wrong, [dict(e, verdict="survived") if e["name"] == "low" else e for e in self.entries])
        result = self.run_canary_on(wrong, "--work", self.tmp / "work-wrong", "--mutant", "low")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("| `low` | calc/calc.mbt:17 | survived | killed | killed |", result.stdout)

    def test_a_shard_runs_its_part_and_compares_nothing(self):
        out = self.tmp / "shard"
        result = self.run_canary_on(self.data, "--work", self.tmp / "work-shard", "--out", out,
                                    "--mutant", "low", "--mutant", "low-above", "--shard", "2/2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([r["listed"]["name"] for r in read_lines(out / "mutants.jsonl")], ["low-above"])
        self.assertFalse((out / "canary.json").exists())

    def test_the_replay_stops_unless_the_toolchain_the_commit_pins_is_on_path(self):
        # #308: "The replay installs the toolchain pinned at d953f320."
        fake = self.tmp / "fake-bin"
        fake.mkdir(exist_ok=True)
        (fake / "moonc").write_text('#!/bin/sh\necho "v0.0.1+fake (2020-01-01)"\n')
        (fake / "moonc").chmod(0o755)
        log_before = self.log.read_text() if self.log.exists() else ""
        env = dict(os.environ, PATH=f"{fake}{os.pathsep}{os.environ['PATH']}")
        result = self.run_canary_on(self.data, "--work", self.work, env=env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        pinned = (REPO / ".moonbit-version").read_text().strip()
        self.assertIn(f"{self.commit} pins MoonBit {pinned}, but moonc on PATH is 0.0.1+fake", result.stderr)
        self.assertIn("canary.py install", result.stderr)
        # It ran no moon.
        self.assertEqual(self.log.read_text() if self.log.exists() else "", log_before)

    def test_a_commit_that_no_longer_builds_stops_the_replay_and_says_what_moves_the_canary(self):
        # #308: "When that toolchain can no longer build that commit, the
        # canary moves to a new commit and new recorded verdicts, with the
        # maintainer's approval."
        broken = self.tmp / "broken-moon"
        broken.write_text('#!/bin/sh\necho "error: no build" >&2\nexit 1\n')
        broken.chmod(0o755)
        result = subprocess.run([sys.executable, str(CANARY), "run", "--repo", str(self.repo), "--data",
                                 str(self.data), "--explained", str(self.explained), "--moon", str(broken),
                                 "--work", str(self.tmp / "work-broken"), "--mutant", "low"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the canary moves to a new commit with new recorded verdicts, with the maintainer's"
                      " approval", result.stderr)

    def test_install_runs_the_install_script_of_the_commit_in_its_checkout(self):
        work = self.tmp / "work-install"
        result = subprocess.run([sys.executable, str(CANARY), "install", "--repo", str(self.repo), "--data",
                                 str(self.data), "--explained", str(self.explained), "--work", str(work)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.marker.read_text().strip(), f"pinned {work / 'source'}")

    def test_a_checkout_that_was_changed_or_is_of_another_commit_is_made_again(self):
        # CONTRIBUTING, "The canary": the replay runs on the commit's own
        # source, so a checkout left changed is not reused.
        work = self.tmp / "work-again"
        install = [sys.executable, str(CANARY), "install", "--repo", str(self.repo), "--data", str(self.data),
                   "--explained", str(self.explained), "--work", str(work)]
        self.assertEqual(subprocess.run(install, capture_output=True).returncode, 0)
        calc = work / "source" / "calc" / "calc.mbt"
        calc.write_text("changed\n")
        result = subprocess.run(install, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calc.read_text(), (FIXTURE / "calc" / "calc.mbt").read_text())
        git(work / "source", "checkout", "-q", "--detach", "HEAD")
        git(work / "source", "commit", "-q", "--allow-empty", "-m", "another commit")
        result = subprocess.run(install, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(git(work / "source", "rev-parse", "HEAD").strip(), self.commit)
        # A directory that is no checkout is in the way.
        other = self.tmp / "work-in-the-way"
        (other / "source").mkdir(parents=True)
        result = subprocess.run(install[:-1] + [str(other)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("is in the way of the canary's checkout: remove it", result.stderr)


def entry(name, verdict, file="calc/calc.mbt", offset=0, original="<=", replacement="<", **more):
    """A mutant of a canary, by offset, with its recorded verdict."""
    fields = {"name": name, "file": file, "offset": offset, "original": original, "replacement": replacement,
              "operator": "ROR", "commit": "0" * 40, "verdict": verdict, "tests": ["mutation/fixture/calc"]}
    fields.update(more)
    if "outside" not in fields:
        fields.setdefault("v1", f"calc/calc.mbt,in_range,ROR,<=,<,{offset}")
    return fields


def record(name, outcome, **more):
    """A runner's record of a listed mutant."""
    return {"id": f"id-{name}", "file": "calc/calc.mbt", "line": 1, "outcome": outcome, "killing_tests": [],
            "listed": {"name": name}, **more}


class CompareTest(unittest.TestCase):
    """canary.py compare, on runs made up for each rule."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-canary-compare-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def compare(self, entries, records, explained="", *args):
        data, toml, out = self.tmp / "mutants.jsonl", self.tmp / "explained.toml", self.tmp / "out"
        write_lines(data, entries)
        toml.write_text(explained, encoding="utf-8")
        out.mkdir(exist_ok=True)
        write_lines(out / "mutants.jsonl", records)
        result = run_canary("compare", "--data", data, "--explained", toml, *args, out)
        summary = json.loads((out / "canary.json").read_text()) if (out / "canary.json").exists() else None
        return result, summary

    def test_a_replay_that_gives_every_recorded_verdict_passes(self):
        entries = [entry("a", "killed"), entry("b", "survived"), entry("c", "unviable"), entry("d", "timed out")]
        records = [record("a", "killed"), record("b", "survived"), record("c", "unviable"), record("d", "timed out")]
        result, summary = self.compare(entries, records)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((summary["mutants"], summary["matched"], summary["unexplained"]), (4, 4, []))
        self.assertIn("Every verdict is the recorded one, or an explained difference.", result.stdout)

    def test_a_difference_fails_the_replay(self):
        # #308: "A difference that is not on that list fails the replay."
        result, summary = self.compare([entry("a", "killed"), entry("b", "survived")],
                                       [record("a", "survived"), record("b", "survived")])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([(d["mutant"], d["recorded"], d["replayed"]) for d in summary["unexplained"]],
                         [("a", "killed", "survived")])
        self.assertIn("| `a` | calc/calc.mbt:1 | killed | survived |", result.stdout)

    def test_a_time_out_and_a_kill_are_one_verdict(self):
        # #275: "a confirmed time-out counts as killed".
        result, _ = self.compare([entry("a", "killed"), entry("b", "timed out")],
                                 [record("a", "timed out"), record("b", "killed")])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_equivalent_mutant_matches_a_recorded_survivor_and_nothing_else(self):
        # #308: "A mutant that the compiler-output comparison marks
        # equivalent matches a recorded survivor."
        result, summary = self.compare([entry("a", "survived"), entry("b", "killed")],
                                       [record("a", "equivalent"), record("b", "equivalent")])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([(d["mutant"], d["replayed"], d["outcome"]) for d in summary["unexplained"]],
                         [("b", "survived", "equivalent")])

    def test_a_duplicate_takes_the_verdict_of_the_mutant_it_compiles_as(self):
        # CONTRIBUTING, "The compiler's output": a duplicate compiles as an
        # earlier mutant, whose outcome the report gives beside it.
        entries = [entry("a", "killed"), entry("b", "killed"), entry("c", "survived"), entry("d", "survived")]
        records = [record("a", "killed"), record("b", "duplicate", duplicate_of="id-a"),
                   record("c", "equivalent"), record("d", "duplicate", duplicate_of="id-a")]
        result, summary = self.compare(entries, records)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([(d["mutant"], d["replayed"], d["outcome"]) for d in summary["unexplained"]],
                         [("d", "killed", "duplicate")])

    def test_an_unconfirmed_kill_is_a_difference(self):
        result, summary = self.compare([entry("a", "killed")], [record("a", "unconfirmed", first_outcome="killed")])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(summary["unexplained"][0]["replayed"], "unconfirmed")

    def test_a_mutant_that_did_not_run_fails_the_replay(self):
        result, summary = self.compare([entry("a", "killed"), entry("b", "killed")], [record("a", "killed")])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([(d["mutant"], d["replayed"]) for d in summary["unexplained"]], [("b", "not replayed")])

    def test_mutants_chosen_by_name_compare_only_those(self):
        result, summary = self.compare([entry("a", "killed"), entry("b", "killed")], [record("a", "killed")],
                                       "", "--mutant", "a")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(summary["mutants"], 1)

    def test_an_explained_difference_passes_and_shows_with_its_explanation(self):
        # #308: "The maintainer accepts each explained difference before it
        # joins the committed list of explained differences."
        explained = ('[[difference]]\nmutant = "a"\nrecorded = "killed"\nreplayed = "unconfirmed"\n'
                     'category = "flaky test"\nreason = "Its test fails one run in ten without the mutant."\n'
                     'accepted = "https://github.com/hirunefu/smock/issues/275#issuecomment-1"\n')
        result, summary = self.compare([entry("a", "killed"), entry("b", "killed")],
                                       [record("a", "unconfirmed"), record("b", "killed")], explained)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(summary["unexplained"], [])
        self.assertEqual([(d["mutant"], d["category"]) for d in summary["explained"]], [("a", "flaky test")])
        self.assertIn("Its test fails one run in ten without the mutant.", result.stdout)
        # An explanation of another verdict does not explain this one.
        result, summary = self.compare([entry("a", "killed")], [record("a", "survived")], explained)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual([d["mutant"] for d in summary["not_seen"]], ["a"])

    def test_an_explanation_must_name_a_difference_a_category_and_the_acceptance(self):
        good = {"mutant": "a", "recorded": "killed", "replayed": "survived", "category": "time limit",
                "reason": "r", "accepted": "https://github.com/hirunefu/smock/issues/275#issuecomment-1"}
        for field, value, message in (
                ("mutant", "z", "names no mutant of the canary"),
                ("recorded", "survived", "is not the recorded verdict"),
                ("replayed", "killed", "is no difference"),
                ("replayed", "lost", "replayed"),
                ("category", "bad luck", "category"),
                ("accepted", "", "accepted")):
            bad = dict(good, **{field: value})
            text = "[[difference]]\n" + "".join(f"{k} = {json.dumps(v)}\n" for k, v in bad.items())
            result, _ = self.compare([entry("a", "killed")], [record("a", "survived")], text)
            self.assertEqual(result.returncode, 2, (field, result.stdout + result.stderr))
            self.assertIn(message, result.stderr, field)

    def test_a_record_that_names_no_mutant_of_the_canary_is_an_error(self):
        result, _ = self.compare([entry("a", "killed")], [record("a", "killed"), record("x", "killed")])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("names no mutant of the canary", result.stderr)


if __name__ == "__main__":
    unittest.main()
