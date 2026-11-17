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
import posixpath
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
CANARY = HERE / "canary.py"
DATA = REPO / "mutation" / "canary" / "mutants.jsonl"
EXPLAINED = REPO / "mutation" / "canary" / "explained.toml"
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
