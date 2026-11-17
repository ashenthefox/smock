"""Tests of the site-count ratchet (scripts/mutation/ratchet.py), through
its command line, on copies of the fixture module scripts/mutation/fixture
in small git histories.

#309 asks for it: each package's site count, per definition and
operator, is committed and must equal what the site finder gives on the
head; and a package's sites may drop only by as many as the base had in
the definitions a change deletes or changes, unless the change records
the drop, with its reason, in the list of approved drops (CONTRIBUTING.md,
"Mutation runner", "The site counts").

The expected counts come from the fixture's comments, which give each
site of calc's pinned set and what the full set adds (test_mutation.py's
CALC and CALC_OTHERS): in_range has BODY, two ROR and LCR; halve_until
BODY, IFC, ROR, DEL, AOR and INT, and the full set adds IFC's other value
and INT's two others; is_blank three BOOL, BODY, two IFC, NOT and two INT,
and the full set adds IFC's two others; is_odd BODY, NOT and four INT,
and the full set adds INT's 0 for the 2.

They need python3, git and moonc (the toolchain of .moonbit-version).

usage: python3 -m unittest discover -s scripts/mutation -v
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "fixture"
RATCHET = HERE / "ratchet.py"
SITES = HERE / "sites.py"

# calc's counts, per definition, in the pinned set and in the full set.
CALC = [
    ("in_range", {"BODY": 1, "ROR": 2, "LCR": 1}, {"BODY": 1, "ROR": 2, "LCR": 1}),
    ("halve_until", {"BODY": 1, "ROR": 1, "IFC": 1, "DEL": 1, "AOR": 1, "INT": 1},
     {"BODY": 1, "ROR": 1, "IFC": 2, "DEL": 1, "AOR": 1, "INT": 3}),
    ("is_blank", {"BODY": 1, "IFC": 2, "NOT": 1, "BOOL": 3, "INT": 2},
     {"BODY": 1, "IFC": 4, "NOT": 1, "BOOL": 3, "INT": 2}),
    ("is_odd", {"BODY": 1, "NOT": 1, "INT": 4}, {"BODY": 1, "NOT": 1, "INT": 5}),
]
GIT = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]


class History:
    """A copy of the fixture module in a git repository of its own."""

    def __init__(self, tmp):
        self.root = tmp / "module"
        shutil.copytree(FIXTURE, self.root, ignore=shutil.ignore_patterns("_build", "target", ".mooncakes"))
        self.git("init", "-q", "-b", "main")

    def git(self, *args):
        return subprocess.run([*GIT, "-C", str(self.root), *args], capture_output=True, text=True, check=True).stdout

    def ratchet(self, *args, finder=None):
        options = ["--finder", str(finder)] if finder else []
        return subprocess.run([sys.executable, str(RATCHET), "--root", str(self.root), *options, *args],
                              capture_output=True, text=True)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def edit(self, path, old, new):
        """Replaces the one occurrence of old in a file of the module."""
        file = self.root / path
        text = file.read_text()
        if text.count(old) != 1:
            raise AssertionError(f"{path} does not hold {old!r} once")
        file.write_text(text.replace(old, new))

    def drops(self, *lines):
        """Adds lines to the list of approved drops."""
        path = self.root / "mutation" / "approved-drops.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        before = path.read_text() if path.is_file() else ""
        path.write_text(before + "".join(f"{line}\n" for line in lines))

    def counted_base(self):
        """Commits the counts on main, and starts the branch change there."""
        self.ratchet("write")
        self.commit("counts")
        self.git("checkout", "-q", "-b", "change")

    def counts(self, package):
        """The committed counts of a package, as a list of objects."""
        path = self.root / "mutation" / "site-counts" / f"{package}.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]


def finder_without(tmp, condition):
    """A narrowed site finder: it runs sites.py, and leaves out each line
    for which condition, a Python expression over the line's object s,
    holds."""
    script = tmp / "narrowed.py"
    script.write_text(
        "import json, subprocess, sys\n"
        f"result = subprocess.run([sys.executable, {str(SITES)!r}, *sys.argv[1:]], capture_output=True, text=True)\n"
        "sys.stderr.write(result.stderr)\n"
        "for line in result.stdout.splitlines():\n"
        "    s = json.loads(line)\n"
        f"    if not ({condition}):\n"
        "        print(line)\n"
        "sys.exit(result.returncode)\n")
    return f"{sys.executable} {script}"


# is_odd, as calc/calc.mbt has it, with its doc comment.
IS_ODD = """///|
/// Whether `n` is odd.
pub fn is_odd(n : Int32) -> Bool {
  // BODY `{ false }`: killed, by 3.
  // NOT `!` removed: killed, by 3.
  // INT `2` to `3` and to `1`, and INT `0` to `1`: killed, by 3. The full
  // set adds `0` for the `2`.
  // INT `0` to `-1`: survives, since no test has a negative odd number.
  !(n % 2 == 0)
}

"""


class RatchetTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="test-ratchet-"))
        self.history = History(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_the_counts_give_each_definitions_sites_per_operator_in_both_sets(self):
        result = self.history.ratchet("write")
        self.assertEqual(result.returncode, 0, result.stderr)
        # The fixture's packages that hold a site: meter and units came
        # with the importers' credit (#300), same with the comparison of
        # the compiler's output (#303), bounds and host with the native
        # verdicts (#307); dial and probe hold tests alone.
        self.assertEqual(sorted(p.name for p in (self.history.root / "mutation" / "site-counts").iterdir()),
                         ["bounds.jsonl", "calc.jsonl", "forms.jsonl", "host.jsonl", "log.jsonl", "meter.jsonl",
                          "same.jsonl", "shapes.jsonl", "units.jsonl"])
        counts = self.history.counts("calc")
        self.assertEqual([(c["definition"], c["pinned"], c["full"]) for c in counts], CALC)
        self.assertEqual({c["file"] for c in counts}, {"calc/calc.mbt"})
        self.assertEqual([list(c) for c in counts], [["file", "definition", "text", "pinned", "full"]] * 4)

    def test_a_definition_with_sites_of_the_full_set_alone_is_counted(self):
        # By operator set v1 (CONTRIBUTING.md, "Operator set v1"), Pair has
        # no default, so first's BODY site is skipped; its guard binds v,
        # so IFC's true is skipped and only the full set's false remains;
        # and calc is outside STR's scope.
        (self.history.root / "calc" / "pair.mbt").write_text(
            "///|\npub(all) struct Pair {\n  a : Int32\n}\n\n"
            "///|\npub fn first(o : Int32?) -> Pair {\n  guard o is Some(v) else { abort(\"none\") }\n  { a: v }\n}\n")
        self.history.ratchet("write")
        self.assertEqual([(c["file"], c["definition"], c["pinned"], c["full"]) for c in self.history.counts("calc")
                          if c["file"] == "calc/pair.mbt"],
                         [("calc/pair.mbt", "first", {}, {"IFC": 1})])

    def test_the_check_passes_when_the_committed_counts_are_the_trees(self):
        self.history.ratchet("write")
        self.history.commit("counts")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # bounds, calc, forms, host, log, meter, same, shapes and units.
        self.assertIn("the committed site counts of 9 packages are the tree's", result.stdout)

    def test_the_check_fails_when_a_change_alters_sites_and_not_their_counts(self):
        self.history.ratchet("write")
        self.history.commit("counts")
        calc = self.history.root / "calc" / "calc.mbt"
        calc.write_text(calc.read_text().replace("!(n % 2 == 0)", "!(n % 2 == 0) && n > 0"))
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the committed site counts of calc differ from the site finder's on this tree", result.stderr)
        self.assertIn('-{"file":"calc/calc.mbt","definition":"is_odd"', result.stderr)
        self.assertIn("python3 scripts/mutation/ratchet.py write", result.stderr)
        # So does a package whose counts are not committed at all.
        (self.history.root / "mutation" / "site-counts" / "log.jsonl").unlink()
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("the committed site counts of log differ from the site finder's on this tree", result.stderr)

    def test_a_drop_of_exactly_a_deleted_definitions_sites_passes(self):
        self.history.counted_base()
        self.history.edit("calc/calc.mbt", IS_ODD, "")
        self.history.ratchet("write")
        self.history.commit("delete is_odd")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # is_odd held 6 sites of the pinned set and 7 of the full set.
        self.assertIn("ratchet: calc: 19 sites in the pinned set and 24 in the full set, against the base's 25"
                      " and 31; the definitions that the change deletes or changes held 6 and 7.", result.stdout)

    def test_a_changed_definition_may_lose_its_sites(self):
        self.history.counted_base()
        self.history.edit("calc/calc.mbt", "!(n % 2 == 0)", "n % 2 != 0")
        self.history.ratchet("write")
        self.history.commit("simpler is_odd")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_drop_beyond_the_deleted_definitions_sites_with_a_narrowed_finder_fails(self):
        self.history.counted_base()
        # The finder no longer finds calc's comparisons, and the change
        # also deletes is_odd: 6 + 3 sites fewer in the pinned set, of
        # which is_odd held only 6.
        narrowed = finder_without(self.tmp, 's["file"] == "calc/calc.mbt" and s["operator"] == "ROR"')
        self.history.edit("calc/calc.mbt", IS_ODD, "")
        self.history.ratchet("write", finder=narrowed)
        self.history.commit("narrow the finder")
        result = self.history.ratchet("check", "--base", "main", finder=narrowed)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for chosen in ("pinned", "full"):
            self.assertIn(f"ratchet: calc: 3 sites of ROR in the {chosen} set are gone from definitions that the"
                          " change neither deletes nor changes (in_range 2 to 0, halve_until 1 to 0).",
                          result.stderr)
            self.assertIn(f'add "calc ROR {chosen} 3 <reason>" to mutation/approved-drops.txt', result.stderr)
        self.assertNotIn("is_odd", result.stderr)

    def test_a_definition_left_as_it_was_that_loses_every_site_fails(self):
        self.history.counted_base()
        narrowed = finder_without(self.tmp, 's["definition"] == "is_odd"')
        self.history.ratchet("write", finder=narrowed)
        self.history.commit("no site in is_odd")
        result = self.history.ratchet("check", "--base", "main", finder=narrowed)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ratchet: calc: 4 sites of INT in the pinned set are gone from definitions that the change"
                      " neither deletes nor changes (is_odd 4 to 0).", result.stderr)
        self.assertIn("ratchet: calc: 1 site of NOT in the full set is gone", result.stderr)

    def test_a_drop_that_the_change_records_as_approved_passes(self):
        self.history.counted_base()
        narrowed = finder_without(self.tmp, 's["file"] == "calc/calc.mbt" and s["operator"] == "ROR"')
        self.history.ratchet("write", finder=narrowed)
        self.history.drops("calc ROR pinned 3 the finder leaves out comparisons, for this test",
                           "calc ROR full 3 the same")
        self.history.commit("narrow the finder, approved")
        result = self.history.ratchet("check", "--base", "main", finder=narrowed)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ratchet: calc: 3 sites of ROR in the pinned set dropped, as mutation/approved-drops.txt"
                      " records: the finder leaves out comparisons, for this test", result.stdout)

    def test_only_the_lines_that_the_change_adds_approve_a_drop(self):
        # A line the base already has approved an earlier drop.
        self.history.drops("calc ROR pinned 3 an earlier drop", "calc ROR full 3 the same")
        self.history.counted_base()
        narrowed = finder_without(self.tmp, 's["file"] == "calc/calc.mbt" and s["operator"] == "ROR"')
        self.history.ratchet("write", finder=narrowed)
        self.history.commit("narrow the finder")
        result = self.history.ratchet("check", "--base", "main", finder=narrowed)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ratchet: calc: 3 sites of ROR in the pinned set are gone", result.stderr)

    def test_an_approved_drop_must_be_the_drop_the_change_makes(self):
        self.history.counted_base()
        narrowed = finder_without(self.tmp, 's["file"] == "calc/calc.mbt" and s["operator"] == "ROR"')
        self.history.ratchet("write", finder=narrowed)
        self.history.drops("calc ROR pinned 2 too few", "calc ROR full 4 too many", "log STR pinned 1 no such drop")
        self.history.commit("narrow the finder, recorded wrongly")
        result = self.history.ratchet("check", "--base", "main", finder=narrowed)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ratchet: mutation/approved-drops.txt records 2 sites of ROR in the pinned set dropped in"
                      " calc, but the change drops 3", result.stderr)
        self.assertIn("ratchet: mutation/approved-drops.txt records 4 sites of ROR in the full set dropped in"
                      " calc, but the change drops 3", result.stderr)
        self.assertIn("ratchet: mutation/approved-drops.txt records 1 site of STR in the pinned set dropped in"
                      " log, but the change drops none there", result.stderr)
        self.assertNotIn("in the full set are gone", result.stderr)

    def test_a_malformed_line_of_approved_drops_fails(self):
        self.history.counted_base()
        self.history.drops("calc ROR pinned 3", "calc ROR pinned three no number", "calc ROR pinned 0 no site",
                           "calc XOR pinned 1 no such operator", "calc ROR some 1 no such set")
        self.history.commit("malformed lines")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for number in range(1, 6):
            self.assertIn(f"mutation/approved-drops.txt:{number}: should be <package> <operator> <pinned|full>"
                          " <sites> <reason>", result.stderr)

    def test_a_definition_moved_to_another_file_is_the_same_definition(self):
        self.history.counted_base()
        # Within STR's scope: the same sites, nothing dropped.
        self.history.edit("calc/calc.mbt", IS_ODD, "")
        (self.history.root / "calc" / "odd.mbt").write_text(IS_ODD)
        self.history.ratchet("write")
        self.history.commit("move is_odd")
        self.assertEqual(self.history.ratchet("check", "--base", "main").returncode, 0)
        # Out of STR's scope: log/target.mbt is outside it, so is_comment's
        # string is no site there, though the change did not change it.
        is_comment = (self.history.root / "log" / "lines.mbt").read_text().split("///|\n")[2]
        self.history.edit("log/lines.mbt", "///|\n" + is_comment, "")
        target = self.history.root / "log" / "target.mbt"
        target.write_text(target.read_text() + "\n///|\n" + is_comment)
        self.history.ratchet("write")
        self.history.commit("move is_comment out of STR's scope")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ratchet: log: 1 site of STR in the pinned set is gone from definitions that the change"
                      " neither deletes nor changes (is_comment 1 to 0).", result.stderr)

    def test_without_counts_at_the_base_nothing_is_compared(self):
        self.history.commit("no counts")
        self.history.git("checkout", "-q", "-b", "change")
        self.history.edit("calc/calc.mbt", IS_ODD, "")
        self.history.ratchet("write")
        self.history.commit("counts")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("has no committed site counts: nothing to compare with", result.stdout)

    def test_the_base_is_the_merge_base_not_the_tip_of_main(self):
        self.history.counted_base()
        # main moves on: its finder finds each ROR site twice, so a
        # definition the branch left as it was has more sites on main's
        # tip than on the branch, which never had that finder.
        self.history.git("checkout", "-q", "main")
        wider = self.tmp / "wider.py"
        wider.write_text(
            "import json, subprocess, sys\n"
            f"result = subprocess.run([sys.executable, {str(SITES)!r}, *sys.argv[1:]],\n"
            "                        capture_output=True, text=True)\n"
            "for line in result.stdout.splitlines():\n"
            "    print(line)\n"
            "    if json.loads(line)['operator'] == 'ROR':\n"
            "        print(line)\n"
            "sys.exit(result.returncode)\n")
        self.history.ratchet("write", finder=f"{sys.executable} {wider}")
        self.history.commit("a wider finder")
        self.history.git("checkout", "-q", "change")
        self.history.edit("calc/calc.mbt", IS_ODD, "")
        self.history.ratchet("write")
        self.history.commit("delete is_odd")
        result = self.history.ratchet("check", "--base", "main")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("the definitions that the change deletes or changes held 6 and 7", result.stdout)

    def test_a_base_that_git_does_not_know_cannot_be_judged(self):
        self.history.counted_base()
        result = self.history.ratchet("check", "--base", "nowhere")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("ratchet: git merge-base HEAD nowhere", result.stderr)


if __name__ == "__main__":
    unittest.main()
